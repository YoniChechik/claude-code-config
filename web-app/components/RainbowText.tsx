interface RainbowTextProps {
  text: string;
}

const RAINBOW_COLORS = [
  "#FF0000",
  "#FF7700",
  "#FFFF00",
  "#00AA00",
  "#0055FF",
  "#4B0082",
  "#9400D3",
];

export default function RainbowText({ text }: RainbowTextProps) {
  const regex = /ultrathink/gi;
  const parts: JSX.Element[] = [];
  let lastIndex = 0;
  let match;

  while ((match = regex.exec(text)) !== null) {
    if (match.index > lastIndex) {
      parts.push(<span key={`text-${lastIndex}`}>{text.slice(lastIndex, match.index)}</span>);
    }

    const word = match[0];
    const rainbowLetters = word.split("").map((letter, i) => (
      <span key={`${match.index}-${i}`} style={{ color: RAINBOW_COLORS[i % RAINBOW_COLORS.length] }}>
        {letter}
      </span>
    ));
    parts.push(<span key={`rainbow-${match.index}`}>{rainbowLetters}</span>);

    lastIndex = regex.lastIndex;
  }

  if (lastIndex < text.length) {
    parts.push(<span key={`text-${lastIndex}`}>{text.slice(lastIndex)}</span>);
  }

  if (parts.length === 0) {
    return <span>{text}</span>;
  }

  return <>{parts}</>;
}
