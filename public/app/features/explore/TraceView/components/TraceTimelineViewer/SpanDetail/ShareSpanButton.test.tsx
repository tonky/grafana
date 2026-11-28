import { act, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

import { type LinkModel, textUtil } from '@grafana/data';

import { ShareSpanButton } from './ShareSpanButton';

describe('ShareSpanButton', () => {
  const originalIsSecureContext = window.isSecureContext;

  beforeEach(() => {
    jest.useFakeTimers();
    Object.assign(window, { isSecureContext: true });
  });

  afterEach(() => {
    Object.assign(window, { isSecureContext: originalIsSecureContext });
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it('copies the span deep-link as an absolute URL', async () => {
    const user = userEvent.setup({ advanceTimers: jest.advanceTimersByTime });

    render(
      <ShareSpanButton
        focusSpanLink={
          {
            href: '/explore?spanId=abc',
            title: 'Deep link to this span',
            origin: {},
          } as unknown as LinkModel
        }
      />
    );

    await user.click(screen.getByTestId('share-span-button'));
    await act(async () => { await jest.runOnlyPendingTimersAsync(); });

    expect(await navigator.clipboard.readText()).toBe('http://localhost/explore?spanId=abc');
  });

  it.each([
    { name: 'the span href is missing', href: undefined, sanitized: undefined },
    { name: 'sanitization blanks the span href', href: '/explore?spanId=abc', sanitized: 'about:blank' },
    { name: 'sanitization returns an empty string', href: '/explore?spanId=abc', sanitized: '' },
    { name: 'the span href is not a valid URL', href: 'https://exa mple.com', sanitized: undefined },
  ])('copies the current page URL when $name', async ({ href, sanitized }) => {
    const user = userEvent.setup({ advanceTimers: jest.advanceTimersByTime });
    if (sanitized !== undefined) {
      jest.spyOn(textUtil, 'sanitizeUrl').mockReturnValue(sanitized);
    }

    render(
      <ShareSpanButton
        focusSpanLink={
          {
            href,
            title: 'Deep link to this span',
            origin: {},
          } as unknown as LinkModel
        }
      />
    );

    await user.click(screen.getByTestId('share-span-button'));
    await act(async () => { await jest.runOnlyPendingTimersAsync(); });

    expect(await navigator.clipboard.readText()).toBe('http://localhost/');
  });
});
