import { detectAndParseUrls } from '../lib/link-detector';

describe('detectAndParseUrls', () => {
  it('should detect http:// URLs', () => {
    const text = 'Check out http://example.com for more info';
    const segments = detectAndParseUrls(text);

    expect(segments).toHaveLength(3);
    expect(segments[0]).toEqual({ type: 'text', content: 'Check out ' });
    expect(segments[1]).toEqual({ type: 'url', content: 'http://example.com' });
    expect(segments[2]).toEqual({ type: 'text', content: ' for more info' });
  });

  it('should detect https:// URLs', () => {
    const text = 'Visit https://secure-site.com for details';
    const segments = detectAndParseUrls(text);

    expect(segments).toHaveLength(3);
    expect(segments[0]).toEqual({ type: 'text', content: 'Visit ' });
    expect(segments[1]).toEqual({ type: 'url', content: 'https://secure-site.com' });
    expect(segments[2]).toEqual({ type: 'text', content: ' for details' });
  });

  it('should detect www. URLs', () => {
    const text = 'Go to www.example.org for more';
    const segments = detectAndParseUrls(text);

    expect(segments).toHaveLength(3);
    expect(segments[0]).toEqual({ type: 'text', content: 'Go to ' });
    expect(segments[1]).toEqual({ type: 'url', content: 'www.example.org' });
    expect(segments[2]).toEqual({ type: 'text', content: ' for more' });
  });

  it('should trim trailing punctuation', () => {
    const text = 'Visit https://example.com. Also check https://test.org,';
    const segments = detectAndParseUrls(text);

    // Should have: text, url, text(.), text, url, text(,)
    expect(segments).toHaveLength(6);
    expect(segments[1]).toEqual({ type: 'url', content: 'https://example.com' });
    expect(segments[2]).toEqual({ type: 'text', content: '.' });
    expect(segments[4]).toEqual({ type: 'url', content: 'https://test.org' });
    expect(segments[5]).toEqual({ type: 'text', content: ',' });
  });

  it('should detect multiple URLs in same text', () => {
    const text = 'Here are three links: http://first.com and https://second.com and www.third.com';
    const segments = detectAndParseUrls(text);

    const urls = segments.filter(s => s.type === 'url');
    expect(urls).toHaveLength(3);
    expect(urls[0].content).toBe('http://first.com');
    expect(urls[1].content).toBe('https://second.com');
    expect(urls[2].content).toBe('www.third.com');
  });

  it('should not affect text without URLs', () => {
    const text = 'This is plain text without any links. Just normal content here.';
    const segments = detectAndParseUrls(text);

    expect(segments).toHaveLength(1);
    expect(segments[0]).toEqual({ type: 'text', content: text });
  });

  it('should handle URLs with paths and query parameters', () => {
    const text = 'Visit https://example.com/path/to/page?query=test&foo=bar for details';
    const segments = detectAndParseUrls(text);

    expect(segments).toHaveLength(3);
    expect(segments[1]).toEqual({ type: 'url', content: 'https://example.com/path/to/page?query=test&foo=bar' });
  });
});
