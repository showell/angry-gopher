import { drainSse } from './sse';

describe('drainSse', () => {
  it('parses named events, default message events, ids, and ignores pings', () => {
    const got: Array<{ event: string; data: string; id?: string }> = [];
    const rest = drainSse(
      'event: backlog-size\ndata: 2\n\n' +
        'id: 0\ndata: {"index":0}\n\n' +
        ': ping\n\n' +
        'id: 1\ndata: {"index":1}\n\n' +
        'id: 2\ndata: {"partial":',
      (event, data, id) => {
        got.push({ event, data, id });
      },
    );
    expect(got).toEqual([
      { event: 'backlog-size', data: '2', id: undefined },
      { event: 'message', data: '{"index":0}', id: '0' },
      { event: 'message', data: '{"index":1}', id: '1' },
    ]);
    expect(rest).toBe('id: 2\ndata: {"partial":');
  });
});
