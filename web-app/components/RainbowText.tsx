interface RainbowTextProps {
  text: string;
}

const RAINBOW_COLORS = [
  "#FF0000", // red
  "#FF7700", // orange
  "#FFFF00", // yellow
  "#00AA00", // green
  "#0055FF", // blue
  "#4B0082", // indigo
  "#9400D3", // violet
];

export default function RainbowText({ text }: RainbowTextProps) {
  const regex = /ultrathink/gi;
  const parts: JSX.Element[] = [];
  let lastIndex = 0;
  let match;

  while ((match = regex.exec(text)) !== null) {
    // Add text before match
    if (match.index > lastIndex) {
      parts.push(<span key={`text-${lastIndex}`}>{text.slice(lastIndex, match.index)}</span>);
    }

    // Add rainbow colored letters
    const word = match[0];
    const rainbowLetters = word.split("").map((letter, i) => (
      <span key={`${match.index}-${i}`} style={{ color: RAINBOW_COLORS[i % RAINBOW_COLORS.length] }}>
        {letter}
      </span>
    ));
    parts.push(<span key={`rainbow-${match.index}`}>{rainbowLetters}</span>);

    lastIndex = regex.lastIndex;
  }

  // Add remaining text after last match
  if (lastIndex < text.length) {
    parts.push(<span key={`text-${lastIndex}`}>{text.slice(lastIndex)}</span>);
  }

  // If no matches, return original text
  if (parts.length === 0) {
    return <span>{text}</span>;
  }

  return <>{parts}</>;
}
