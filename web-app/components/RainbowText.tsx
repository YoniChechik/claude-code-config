import { detectAndParseUrls } from "@/lib/link-detector";

const RAINBOW_COLORS = [
  "#FF0000",
  "#FF7700",
  "#FFFF00",
  "#00AA00",
  "#0055FF",
  "#4B0082",
  "#9400D3",
];

interface RainbowTextProps {
  text: string;
}

function applyRainbowToText(text: string, keyPrefix: string): React.JSX.Element[] {
  const regex = /ultrathink/gi;
  const parts: React.JSX.Element[] = [];
  let lastIndex = 0;
  let match: RegExpExecArray | null;

  while ((match = regex.exec(text)) !== null) {
    const matchIndex = match.index;
    if (matchIndex > lastIndex) {
      parts.push(<span key={`${keyPrefix}-text-${lastIndex}`}>{text.slice(lastIndex, matchIndex)}</span>);
    }

    const word = match[0];
    const rainbowLetters = word.split("").map((letter, i) => (
      <span key={`${keyPrefix}-${matchIndex}-${i}`} style={{ color: RAINBOW_COLORS[i % RAINBOW_COLORS.length] }}>
        {letter}
      </span>
    ));
    parts.push(<span key={`${keyPrefix}-rainbow-${matchIndex}`}>{rainbowLetters}</span>);

    lastIndex = regex.lastIndex;
  }

  if (lastIndex < text.length) {
    parts.push(<span key={`${keyPrefix}-text-${lastIndex}`}>{text.slice(lastIndex)}</span>);
  }

  if (parts.length === 0) {
    return [<span key={`${keyPrefix}-plain`}>{text}</span>];
  }

  return parts;
}

export default function RainbowText({ text }: RainbowTextProps) {
  const segments = detectAndParseUrls(text);
  const parts: React.JSX.Element[] = [];

  segments.forEach((segment, index) => {
    if (segment.type === 'url') {
      const url = segment.content.startsWith('www.')
        ? `https://${segment.content}`
        : segment.content;

      const linkContent = applyRainbowToText(segment.content, `link-${index}`);

      parts.push(
        <a
          key={`url-${index}`}
          href={url}
          target="_blank"
          rel="noopener noreferrer"
          className="underline hover:opacity-80"
        >
          {linkContent}
        </a>
      );
    } else {
      parts.push(...applyRainbowToText(segment.content, `text-${index}`));
    }
  });

  return <>{parts}</>;
}
