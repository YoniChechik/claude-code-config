export interface TextSegment {
  type: 'text' | 'url';
  content: string;
}

/**
 * Detects URLs in text and returns an array of text segments.
 * URLs are identified by http://, https://, or www. prefixes.
 * Trailing punctuation is trimmed from detected URLs.
 */
export function detectAndParseUrls(text: string): TextSegment[] {
  if (!text) {
    return [];
  }

  const urlPattern = /(https?:\/\/[^\s]+|www\.[^\s]+)/gi;
  const segments: TextSegment[] = [];
  let lastIndex = 0;

  let match;
  while ((match = urlPattern.exec(text)) !== null) {
    // Add text before the URL
    if (match.index > lastIndex) {
      segments.push({
        type: 'text',
        content: text.slice(lastIndex, match.index),
      });
    }

    // Trim trailing punctuation from URL
    let url = match[0];
    const trailingPunctuation = /[.,;:!?)\]]+$/;
    const punctMatch = url.match(trailingPunctuation);
    let trailingPunct = '';

    if (punctMatch) {
      trailingPunct = punctMatch[0];
      url = url.slice(0, -trailingPunct.length);
    }

    // Add the URL segment
    segments.push({
      type: 'url',
      content: url,
    });

    // If we trimmed punctuation, add it as text
    if (trailingPunct) {
      segments.push({
        type: 'text',
        content: trailingPunct,
      });
    }

    lastIndex = match.index + match[0].length;
  }

  // Add remaining text after last URL
  if (lastIndex < text.length) {
    segments.push({
      type: 'text',
      content: text.slice(lastIndex),
    });
  }

  // If no URLs found, return the entire text as a single segment
  if (segments.length === 0) {
    segments.push({
      type: 'text',
      content: text,
    });
  }

  return segments;
}
