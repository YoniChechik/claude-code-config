export const mockFetchSuccess = (data: any) => {
  (global.fetch as jest.Mock).mockResolvedValue({
    ok: true,
    json: async () => data,
  });
};

export const mockFetchError = (status: number, message: string) => {
  (global.fetch as jest.Mock).mockResolvedValue({
    ok: false,
    status,
    json: async () => ({ error: message }),
  });
};

export const setupFetchMock = () => {
  global.fetch = jest.fn();
  return global.fetch as jest.Mock;
};

export const waitForNextTick = () =>
  new Promise((resolve) => setTimeout(resolve, 0));

export const waitForTime = (ms: number) =>
  new Promise((resolve) => setTimeout(resolve, ms));
