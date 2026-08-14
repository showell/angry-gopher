export type SseHandlers = {
  onEvent: (event: string, data: string, id?: string) => void;
  onError?: () => void;
};

export function drainSse(
  buf: string,
  onEvent: (event: string, data: string, id?: string) => void,
): string {
  let rest = buf;
  while (true) {
    const split = rest.indexOf('\n\n');
    if (split < 0) {
      return rest;
    }
    const raw = rest.slice(0, split);
    rest = rest.slice(split + 2);
    let event = 'message';
    let id: string | undefined;
    const dataLines: string[] = [];
    const lines = raw.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (!line || line.charAt(0) === ':') {
        continue;
      }
      const colon = line.indexOf(':');
      const field = colon < 0 ? line : line.slice(0, colon);
      let value = colon < 0 ? '' : line.slice(colon + 1);
      if (value.charAt(0) === ' ') {
        value = value.slice(1);
      }
      if (field === 'event') {
        event = value;
      } else if (field === 'data') {
        dataLines.push(value);
      } else if (field === 'id') {
        id = value;
      }
    }
    if (dataLines.length) {
      onEvent(event, dataLines.join('\n'), id);
    }
  }
}

export function openEventSource(
  url: string,
  headers: Record<string, string>,
  handlers: SseHandlers,
): () => void {
  const xhr = new XMLHttpRequest();
  xhr.open('GET', url);
  xhr.setRequestHeader('Accept', 'text/event-stream');
  xhr.setRequestHeader('Cache-Control', 'no-cache');
  const keys = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    xhr.setRequestHeader(keys[i], headers[keys[i]]);
  }
  let seen = 0;
  let buf = '';
  xhr.onprogress = function () {
    const chunk = xhr.responseText.slice(seen);
    seen = xhr.responseText.length;
    buf = drainSse(buf + chunk, handlers.onEvent);
  };
  xhr.onerror = function () {
    if (handlers.onError) {
      handlers.onError();
    }
  };
  xhr.send();
  return function () {
    xhr.abort();
  };
}
