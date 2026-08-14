import { htmlToNodes } from './htmlToNodes';

describe('htmlToNodes', () => {
  it('maps a MSG_ pill', () => {
    const tree = htmlToNodes(
      '<p>see <a href="#msg-yo_1" class="msg-ref">MSG_yo_1</a></p>\n',
    );
    expect(tree).toEqual([
      {
        kind: 'p',
        children: [
          { kind: 'text', text: 'see ' },
          { kind: 'msgref', id: 'yo_1', text: 'MSG_yo_1' },
        ],
        malformed: false,
      },
    ]);
  });

  it('maps a quote fence and hard-wrap breaks', () => {
    const tree = htmlToNodes(
      '<p>In <a href="#msg-yo_1" class="msg-ref">MSG_yo_1</a> you said:<br>\n</p>\n<pre class="chat-quote">hello</pre>\n',
    );
    expect(tree[0].kind).toBe('p');
    expect(tree[1]).toEqual({ kind: 'quote', text: 'hello' });
  });

  it('maps emphasis, strong, and code', () => {
    const tree = htmlToNodes(
      '<p><strong>bold</strong> <em>em</em> <code>x</code></p>',
    );
    expect(tree[0]).toEqual({
      kind: 'p',
      malformed: false,
      children: [
        { kind: 'strong', children: [{ kind: 'text', text: 'bold' }] },
        { kind: 'text', text: ' ' },
        { kind: 'em', children: [{ kind: 'text', text: 'em' }] },
        { kind: 'text', text: ' ' },
        { kind: 'code', text: 'x' },
      ],
    });
  });

  it('maps fenced code with a language', () => {
    const tree = htmlToNodes(
      '<pre><code class="language-js">const x = 1;</code></pre>\n',
    );
    expect(tree).toEqual([{ kind: 'pre', text: 'const x = 1;', lang: 'js' }]);
  });

  it('keeps same-origin images and drops protocol-relative ones', () => {
    expect(
      htmlToNodes('<img src="/chat/c/1_2/t/uploads/aa.png" alt="pic">'),
    ).toEqual([
      {
        kind: 'img',
        src: '/chat/c/1_2/t/uploads/aa.png',
        alt: 'pic',
        width: undefined,
        height: undefined,
      },
    ]);
    expect(htmlToNodes('<img src="//evil.example/x.png" alt="x">')[0].kind).toBe(
      'unknown',
    );
  });

  it('flags the hostile placeholder', () => {
    const tree = htmlToNodes(
      '<p class="md-malformed">⚠️ malformed markdown — not rendered</p>\n',
    );
    expect(tree[0].kind).toBe('p');
    if (tree[0].kind === 'p') {
      expect(tree[0].malformed).toBe(true);
    }
  });

  it('decodes entities in text', () => {
    const tree = htmlToNodes('<p>a &amp; b &lt; c</p>');
    expect(tree[0]).toMatchObject({
      kind: 'p',
      children: [{ kind: 'text', text: 'a & b < c' }],
    });
  });
});
