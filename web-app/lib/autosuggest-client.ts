import type { SlashCommand } from "./types";

// Public functions
export function fuzzyScore(pattern: string, candidate: string): number {
  const patternLower = pattern.toLowerCase();
  const candidateLower = candidate.toLowerCase();

  if (patternLower === candidateLower) {
    return 0;
  }

  if (candidateLower.startsWith(patternLower)) {
    return 1;
  }

  let patternIndex = 0;
  let candidateIndex = 0;
  let totalDistance = 0;
  let lastMatchPos = -1;

  while (patternIndex < patternLower.length && candidateIndex < candidateLower.length) {
    if (patternLower[patternIndex] === candidateLower[candidateIndex]) {
      const distance = candidateIndex - lastMatchPos - 1;
      totalDistance += distance;
      lastMatchPos = candidateIndex;
      patternIndex++;
    }
    candidateIndex++;
  }

  if (patternIndex === patternLower.length) {
    const normalizedDistance = Math.min(10, totalDistance / patternLower.length);
    return 2 + normalizedDistance;
  }

  return 999;
}

export function fuzzyMatchCommands(
  pattern: string,
  commands: SlashCommand[]
): SlashCommand[] {
  const scored = commands
    .map((cmd) => ({
      cmd,
      score: fuzzyScore(pattern, cmd.name),
    }))
    .filter(({ score }) => score < 999)
    .sort((a, b) => a.score - b.score);

  return scored.map(({ cmd }) => cmd);
}
